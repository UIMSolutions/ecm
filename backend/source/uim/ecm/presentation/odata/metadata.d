module uim.ecm.presentation.odata.metadata;

enum metadataXml = q"XML
<?xml version="1.0" encoding="utf-8"?>
<edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
  <edmx:DataServices>
    <Schema Namespace="ECM" xmlns="http://docs.oasis-open.org/odata/ns/edm">
      <EntityType Name="Notification">
        <Key><PropertyRef Name="ID"/></Key>
        <Property Name="ID" Type="Edm.String" Nullable="false"/>
        <Property Name="Kind" Type="Edm.String"/>
        <Property Name="Actor" Type="Edm.String"/>
        <Property Name="Subject" Type="Edm.String"/>
        <Property Name="Detail" Type="Edm.String"/>
        <Property Name="WorkspaceID" Type="Edm.String"/>
        <Property Name="RefID" Type="Edm.String"/>
        <Property Name="Read" Type="Edm.Boolean"/>
        <Property Name="CreatedAt" Type="Edm.DateTimeOffset" Precision="0"/>
      </EntityType>
      <EntityType Name="Tenant">
        <Key><PropertyRef Name="ID"/></Key>
        <Property Name="ID" Type="Edm.String" Nullable="false"/>
        <Property Name="Name" Type="Edm.String" Nullable="false" MaxLength="255"/>
        <Property Name="Slug" Type="Edm.String" Nullable="false" MaxLength="40"/>
        <Property Name="Active" Type="Edm.Boolean"/>
        <Property Name="CreatedAt" Type="Edm.DateTimeOffset" Precision="0"/>
      </EntityType>
      <EntityType Name="Workspace">
        <Key><PropertyRef Name="ID"/></Key>
        <Property Name="ID" Type="Edm.String" Nullable="false"/>
        <Property Name="TenantID" Type="Edm.String"/>
        <Property Name="Name" Type="Edm.String" Nullable="false" MaxLength="255"/>
        <Property Name="Description" Type="Edm.String"/>
        <Property Name="MyRole" Type="Edm.String"/>
        <Property Name="CreatedAt" Type="Edm.DateTimeOffset" Precision="0"/>
      </EntityType>
      <EntityType Name="Member">
        <Key><PropertyRef Name="ID"/></Key>
        <Property Name="ID" Type="Edm.String" Nullable="false"/>
        <Property Name="WorkspaceID" Type="Edm.String" Nullable="false"/>
        <Property Name="UserID" Type="Edm.String"/>
        <Property Name="Username" Type="Edm.String"/>
        <Property Name="Role" Type="Edm.String"/>
        <Property Name="CreatedAt" Type="Edm.DateTimeOffset" Precision="0"/>
      </EntityType>
      <EntityType Name="User">
        <Key><PropertyRef Name="ID"/></Key>
        <Property Name="ID" Type="Edm.String" Nullable="false"/>
        <Property Name="TenantID" Type="Edm.String"/>
        <Property Name="Username" Type="Edm.String" Nullable="false" MaxLength="64"/>
        <Property Name="DisplayName" Type="Edm.String"/>
        <Property Name="Email" Type="Edm.String"/>
        <Property Name="Role" Type="Edm.String"/>
        <Property Name="Active" Type="Edm.Boolean"/>
        <Property Name="External" Type="Edm.Boolean"/>
        <Property Name="CreatedAt" Type="Edm.DateTimeOffset" Precision="0"/>
      </EntityType>
      <EntityType Name="Folder">
        <Key><PropertyRef Name="ID"/></Key>
        <Property Name="ID" Type="Edm.String" Nullable="false"/>
        <Property Name="WorkspaceID" Type="Edm.String" Nullable="false"/>
        <Property Name="ParentID" Type="Edm.String"/>
        <Property Name="Name" Type="Edm.String" Nullable="false" MaxLength="255"/>
        <Property Name="CreatedAt" Type="Edm.DateTimeOffset" Precision="0"/>
      </EntityType>
      <EntityType Name="Document" HasStream="true">
        <Key><PropertyRef Name="ID"/></Key>
        <Property Name="ID" Type="Edm.String" Nullable="false"/>
        <Property Name="WorkspaceID" Type="Edm.String" Nullable="false"/>
        <Property Name="FolderID" Type="Edm.String"/>
        <Property Name="Name" Type="Edm.String" Nullable="false" MaxLength="255"/>
        <Property Name="Title" Type="Edm.String"/>
        <Property Name="MimeType" Type="Edm.String"/>
        <Property Name="Size" Type="Edm.Int32"/>
        <Property Name="Revision" Type="Edm.Int32"/>
        <Property Name="Status" Type="Edm.String"/>
        <Property Name="CreatedBy" Type="Edm.String"/>
        <Property Name="CreatedAt" Type="Edm.DateTimeOffset" Precision="0"/>
        <Property Name="ModifiedAt" Type="Edm.DateTimeOffset" Precision="0"/>
        <Property Name="SearchSnippet" Type="Edm.String"/>
        <Property Name="SearchScore" Type="Edm.Double"/>
      </EntityType>
      <Action Name="Publish" IsBound="true">
        <Parameter Name="in" Type="ECM.Document" Nullable="false"/>
        <ReturnType Type="ECM.Document"/>
      </Action>
      <Action Name="Archive" IsBound="true">
        <Parameter Name="in" Type="ECM.Document" Nullable="false"/>
        <ReturnType Type="ECM.Document"/>
      </Action>
      <Action Name="Reindex"><ReturnType Type="Edm.Int32"/></Action>
      <Action Name="MarkAllNotificationsRead"><ReturnType Type="Edm.Int32"/></Action>
      <EntityContainer Name="Container">
        <EntitySet Name="Notifications" EntityType="ECM.Notification"/>
        <EntitySet Name="Tenants" EntityType="ECM.Tenant"/>
        <EntitySet Name="Workspaces" EntityType="ECM.Workspace"/>
        <EntitySet Name="Members" EntityType="ECM.Member"/>
        <EntitySet Name="Users" EntityType="ECM.User"/>
        <EntitySet Name="Folders" EntityType="ECM.Folder"/>
        <EntitySet Name="Documents" EntityType="ECM.Document"/>
        <ActionImport Name="Reindex" Action="ECM.Reindex"/>
        <ActionImport Name="MarkAllNotificationsRead" Action="ECM.MarkAllNotificationsRead"/>
      </EntityContainer>
    </Schema>
  </edmx:DataServices>
</edmx:Edmx>
XML";
